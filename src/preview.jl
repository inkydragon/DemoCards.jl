"""
    preview_demos(demo_path; kwargs...)

Generate a docs preview for a single demo card.

# Return values

* `index_file`: absolute path to the index file of the demo page. You can open this in your browser
  and see the generated demos.

# Arguments

* `demo_path`: path to your demo file or folder. It can be path to the demo file, the folder
  of multiple scripts. If standard demo page folder structure is detected, use it, and otherwise
  will create a preview version of it.

# Parameters

* `theme = "grid"`: the card theme you want to use in the preview
* `assets = String[]`: this is passed to `Documenter.HTML`
* `edit_branch = "master"`: same to that in `makedemos`
* `credit = true`: same to that in `makedemos`
* `require_html = true`: if it needs to trigger the Documenter workflow and generate HTML preview.
  If set to `false`, the return value is then the path to the generated `index.md` file. This is an
  experimental keyword and should not be considered stable.
* `clean = true`: whether you need to first clean up the existing sandbox building dir.

"""
function preview_demos(demo_path::String;
                      theme = "grid",
                      edit_branch = "master",
                      assets = String[],
                      credit = true,
                      require_html = true,
                      clean = true)
    # hard code these args in a sandbox environment -- there's no need for customization
    build = "build"
    src = "src"
    destination = "democards"

    demo_path = abspath(rstrip(demo_path, ['/', '\\']))
    ispath(demo_path) || throw(ArgumentError("demo path does not exists: $demo_path"))

    build_dir = preview_build_dir()
    
    if clean
        # Ref: https://discourse.julialang.org/t/find-what-has-locked-held-a-file/23278/2
        Base.Sys.iswindows() && GC.gc()
        rm(build_dir; force=true, recursive=true)
        mkpath(build_dir)
    end

    page_dir = generate_or_copy_pagedir(demo_path, build_dir)
    copy_assets_and_configs(page_dir, build_dir)

    cd(build_dir) do
        card_templates, card_theme = cardtheme(theme; root = build_dir)
        demos, demos_cb = makedemos(
            basename(page_dir), card_templates;
            root = build_dir,
            src = src,
            build = build,
            destination = destination,
            edit_branch = edit_branch,
            credit = credit
        )

        # In cases that addtional Documenter pipeline is not needed
        # This is mostly for test usage right now and might be changed if there is better solution
        require_html || return abspath(build_dir, src, demos)
        
        format = Documenter.HTML(
            edit_link = edit_branch,
            prettyurls = get(ENV, "CI", nothing) == "true",
            assets = push!(assets, card_theme)
        )
        makedocs(
            root=build_dir,
            source=src,
            format=format,
            pages=[demos],
            sitename="DemoCards Preview"
        )

        source_file = abspath(build_dir, src, destination, basename(page_dir), template_filename)
        source = joinpath(src, destination, basename(page_dir))
        index = get_build_file(source_file, source, destination, build)

        demos_cb()

        return index
    end
end

# A common workflow when previewing demos is to directly refresh the browser this requires us to use
# the same build dir, otherwise, user might be confused why the contents are not updated.
const _preview_build_dir = String[]
function preview_build_dir()
    if isempty(_preview_build_dir)
        build_dir = mktempdir()
        push!(_preview_build_dir, build_dir)
    end
    return _preview_build_dir[1]
end

"""
    generate_or_copy_pagedir(src_path, build_dir)

copy the page folder structure from `src_path` to `build_dir/\$(basename(src_path)`. If `src_path`
does not live in a standard demo page folder structure, generate a preview version.
"""
function generate_or_copy_pagedir(src_path, build_dir)
    ispath(src_path) || throw(ArgumentError("$src_path does not exists"))

    if is_democard(src_path)
        card_path = src_path
        page_dir = infer_pagedir(card_path)
        if isnothing(page_dir)
            page_dir = abspath(build_dir, "preview_page")  
            dst_card_path = abspath(page_dir, "preview_section", basename(card_path))
        else
            dst_card_path = abspath(build_dir, relpath(card_path, dirname(page_dir)))
        end
        mkpath(dirname(dst_card_path))
        cp(card_path, dst_card_path; force=true)
    elseif is_demosection(src_path)
        sec_dir = src_path
        page_dir = infer_pagedir(sec_dir)
        if isnothing(page_dir)
            page_dir = abspath(build_dir, "preview_page")
            dst_sec_dir = abspath(page_dir, basename(sec_dir))
        else
            dst_sec_dir = abspath(build_dir, relpath(sec_dir, dirname(page_dir)))
        end
        mkpath(dirname(dst_sec_dir))
        cp(sec_dir, dst_sec_dir; force=true)
    elseif is_demopage(src_path)
        page_dir = src_path
        cp(page_dir, abspath(build_dir, basename(page_dir)); force=true)
    else
        throw(ArgumentError("failed to parse demo page structure from path: $src_path"))
    end

    return page_dir
end

"""
    copy_assets_and_configs(src_page_dir, dst_build_dir=pwd())

copy only assets, configs and templates from `src_page_dir` to `dst_build_dir`. The folder structure
is preserved under `dst_build_dir/\$(basename(src_page_dir))`

`order` in config files are modified accordingly.
"""
function copy_assets_and_configs(src_page_dir, dst_build_dir=pwd())
    (isabspath(src_page_dir) && isdir(src_page_dir)) || throw(ArgumentError("src_page_dir is expected to be absolute folder path: $src_page_dir"))

    for (root, dirs, files) in walkdir(src_page_dir)
        assets_dirs = intersect(ignored_dirnames, dirs)
        if !isempty(assets_dirs)
            for assets in assets_dirs
                src_assets = abspath(root, assets)
                dst_assets_path = abspath(dst_build_dir, relpath(src_assets, dirname(src_page_dir)))
                mkpath(dirname(dst_assets_path))
                ispath(dst_assets_path) || cp(src_assets, dst_assets_path; force=true)
            end
        end

        if template_filename in files
            src_template_path = abspath(root, template_filename)
            dst_template_path = abspath(dst_build_dir, relpath(src_template_path, dirname(src_page_dir)))
            mkpath(dirname(dst_template_path))
            ispath(dst_template_path) || cp(src_template_path, dst_template_path)
        end
    end

    # modify and copy config.json after the folder structure is already set up
    for (root, dirs, files) in walkdir(src_page_dir)
        if config_filename in files
            src_config_path = abspath(root, config_filename)
            dst_config_path = abspath(dst_build_dir, relpath(src_config_path, dirname(src_page_dir)))
            mkpath(dirname(dst_config_path))

            config = JSON.parsefile(src_config_path)
            config_dir = dirname(dst_config_path)
            if haskey(config, "order")
                order =  [x for x in config["order"] if x in readdir(config_dir)]
                if isempty(order)
                    delete!(config, "order")
                else
                    config["order"] = order
                end
            end

            if !isempty(config)
                # Ref: https://discourse.julialang.org/t/find-what-has-locked-held-a-file/23278/2
                Base.Sys.iswindows() && GC.gc()
                open(dst_config_path, "w") do io
                    JSON.print(io, config)
                end
            end
        end
    end
end
